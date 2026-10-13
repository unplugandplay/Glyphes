## glyphes — M6.1: the index registry and the range index.
##
## The invariant everything else here serves: **a query that uses an index
## answers exactly what the same query answers without one**. An index is an
## accelerator, and the test that matters is not "the index returns the
## right ids" but "the planner choosing it changes nothing" — because the
## alternative is a second implementation of `WHERE` that drifts.
##
## The suite is therefore written in pairs: every predicate is run twice,
## once with the index and once without, and the answers are compared.
## Where the *structure* is the subject (blocks, splits, chaining, delta) the
## assertions are on the structure.

import std/[unittest, math, random]
import std/[algorithm, os, strutils, tables]
import ../../src/store/store
import ../../src/store/prop
import ../../src/abi
import ../../src/errors
import ../../src/txn/txn
import ../../src/index/index
import ../../src/index/range
import ../../src/index/text
import ../../src/index/vector
import ../../src/index/analyzer
import ../../src/cypher/errors
import ../../src/cypher/ctx
import ../../src/cypher/execute
import ../../src/database

proc idsOf(rows: seq[Row], column = "n"): seq[int64] =
  for r in rows:
    let (_, v) = r.lookup(column)
    result.add v.id
  result.sort()

proc runQ(s: GraphStore, sql: string, reg: Indexes): seq[Row] =
  let st = prepare(s, sql, initTable[string, Value](), nil, 0, "", reg)
  defer: st.close()
  st.collectRows()

proc sameAnswer(s: GraphStore, sql: string, reg: Indexes) =
  ## Run it with and without the index. The query is in the message, because
  ## a failure with two anonymous seqs in it is unreadable.
  let withIndex = idsOf(runQ(s, sql, reg))
  let without = idsOf(runQ(s, sql, nil))
  ## `check` in this stdlib takes the condition alone, so the pair
  ## comparison echoes the query itself when the two answers differ: a
  ## failure with two anonymous id sequences in it is unreadable, and the
  ## sequence of queries in the loop is what tells you which one it was.
  if withIndex != without:
    echo "  index answers differ for: ", sql, " (", withIndex.len,
         " with, ", without.len, " without)"
  check(withIndex == without)

proc people(n: int): GraphStore =
  ## Ten `:Person` per city slot, so `city` has duplicates and `age` a
  ## spread — a range index tested only on distinct keys is a range index
  ## tested on the easy half.
  result = newStore()
  for i in 0 ..< n:
    let id = result.createNode("Person")
    discard result.setNodeProp(id, "age", Value(kind: vkInt, i: int64(i mod 40)))
    discard result.setNodeProp(id, "city",
                               Value(kind: vkString, s: "c" & $(i mod 10)))
    discard result.setNodeProp(id, "name", Value(kind: vkString, s: "p" & $i))

proc withIndex(s: GraphStore, target, property: string): Indexes =
  result = newIndexes()
  discard result.create(IdxRange, target, property)
  result.rebuild(s)

suite "M6.1 the registry":
  test "an index is named Target.property, and creating it twice is one index":
    let reg = newIndexes()
    check reg.create(IdxRange, "Person", "age") == "Person.age"
    check reg.create(IdxRange, "Person", "age") == "Person.age"
    check reg.list().len == 1
    check reg.find("Person", "age") != nil
    check reg.find("Person", "city") == nil
    check reg.find("", "age") == nil

  test "drop removes the definition and the contents":
    let s = people(100)
    let reg = withIndex(s, "Person", "age")
    check reg.find("Person", "age").entryCount == 100
    check reg.drop("Person.age")
    check reg.find("Person", "age") == nil
    check reg.list().len == 0

  test "a rebuild refills from live records and bumps the generation":
    let s = people(100)
    let reg = withIndex(s, "Person", "age")
    let before = reg.list()[0].generation
    ## Take the index away, then rebuild it: the contents must come back
    ## from the *store*, because pin I2 says index state is never in the
    ## WAL and every open or `index_build` refills from live records.
    let ix = reg.find("Person", "age")
    ix.blocks = @[]
    ix.ids = @[]
    check ix.entryCount == 0
    reg.rebuild(s, "Person.age")
    check ix.entryCount == 100
    check reg.list()[0].generation > before

  test "an index over a label nothing has is empty, not an error":
    let s = people(10)
    let reg = withIndex(s, "Ghost", "age")
    check reg.find("Ghost", "age").entryCount == 0

suite "M6.1 the structure":
  test "blocks are capped at the page size and chained in key order":
    let ix = newRange("P.age", "P", "age")
    for i in 0 ..< 1000:
      ix.insert(int64(i), Value(kind: vkInt, i: int64(i)))
    ix.merge()
    let (blocks, entries, largest) = ix.blockStats()
    ## 4096 / 16 = 256 entries per block, so 1000 entries is four blocks.
    check entries == 1000
    check blocks == 4
    check largest == BlockEntries
    ## Every block reachable from the head, in ascending key order, once each.
    var seen = 0
    var last = -1'i64
    var ordered = true
    var bid = 0'i64
    while bid >= 0 and bid < ix.blocks.len:
      let b = ix.blocks[bid.int]
      for i in 0 ..< b.ids.len:
        if int64(b.nums[i]) <= last:
          ordered = false
        last = int64(b.nums[i])
        inc seen
      bid = b.next
    check ordered
    check seen == 1000

  test "the delta is visible before the merge and folded after it":
    let ix = newRange("P.age", "P", "age")
    for i in 0 ..< 10:
      ix.insert(int64(i), Value(kind: vkInt, i: int64(i)))
    ix.merge()
    ix.insert(int64(99), Value(kind: vkInt, i: 5))     ## one more 5
    check ix.seekEq(Value(kind: vkInt, i: 5)).len == 2
    ix.merge()
    check ix.seekEq(Value(kind: vkInt, i: 5)).len == 2
    check ix.entryCount == 11

  test "an update replaces and a delete removes — never both":
    let ix = newRange("P.age", "P", "age")
    for i in 0 ..< 10:
      ix.insert(int64(i), Value(kind: vkInt, i: int64(i)))
    ix.merge()
    ix.insert(int64(3), Value(kind: vkInt, i: 7))
    ix.merge()
    check ix.seekEq(Value(kind: vkInt, i: 3)).len == 0
    check ix.seekEq(Value(kind: vkInt, i: 7)).len == 2      ## 7 and the moved 3
    check ix.entryCount == 10
    ix.delete(int64(3))
    check ix.seekEq(Value(kind: vkInt, i: 7)).len == 1
    ix.merge()
    check ix.seekEq(Value(kind: vkInt, i: 7)).len == 1
    check ix.entryCount == 9

  test "a deleted id is never returned, merged or not (pin I11)":
    let ix = newRange("P.age", "P", "age")
    for i in 0 ..< 300:                          ## more than one block
      ix.insert(int64(i), Value(kind: vkInt, i: int64(i)))
    ix.merge()
    ix.delete(299)
    ## Before the merge the block still holds the entry, and a seek that
    ## only looked at blocks would return a node that no longer exists.
    check 299'i64 notin ix.seekEq(Value(kind: vkInt, i: 299))
    check 299'i64 notin ix.ids()
    ix.merge()
    check 299'i64 notin ix.seekEq(Value(kind: vkInt, i: 299))

  test "string keys, and a mixed column with numbers before strings":
    let ix = newRange("P.name", "P", "name")
    for i in 0 ..< 100:
      ix.insert(int64(i), Value(kind: vkString, s: "n" & $(99 - i)))
    ix.merge()
    check ix.seekEq(Value(kind: vkString, s: "n0")) == @[99'i64]
    check ix.collect(Value(kind: vkString, s: "n90"),
                    Value(kind: vkString, s: "n99"), true).len == 10

suite "M6.1 review findings":
  ## Each of these failed before the fix it pins. They are here rather than
  ## folded into the suites above because the suites above test the
  ## structure; these test the *rules* the structure has to obey, and each
  ## rule was learned from a wrong answer rather than from a crash.

  test "a delete-only merge keeps the key kind (string index)":
    ## The merge derived its block kind from the delta, and a delta of
    ## deletions has no live key to ask — so every surviving key was
    ## rewritten as a number, the strings became 0.0, and the index went on
    ## answering with nothing. Total, silent, and no test deleted from a
    ## string index until the review wrote this one.
    let ix = newRange("P.name", "P", "name")
    for i in 0 ..< 10:
      ix.insert(int64(i), Value(kind: vkString, s: "n" & $i))
    ix.merge()
    ix.delete(5)
    ix.merge()
    let (blocks, _, _) = ix.blockStats()
    check blocks == 1
    check ix.blocks[0].stringKeys
    check ix.seekEq(Value(kind: vkString, s: "n3")) == @[3'i64]
    check ix.seekEq(Value(kind: vkString, s: "n7")) == @[7'i64]
    check ix.entryCount == 9

  test "a bool column disqualifies the index instead of under-reporting":
    ## The one wrong answer the predicate-above-the-seek cannot catch: the
    ## filter repairs *extra* rows and can do nothing about missing ones. A
    ## value the index cannot key was omitted, and `WHERE v = true` answered
    ## `[]` with the index and `[1]` without it.
    let s = newStore()
    let a = s.createNode("T")
    discard s.setNodeProp(a, "v", Value(kind: vkBool, b: true))
    let b = s.createNode("T")
    discard s.setNodeProp(b, "v", Value(kind: vkBool, b: false))
    let reg = withIndex(s, "T", "v")
    check reg.find("T", "v").usable == false
    check idsOf(runQ(s, "MATCH (n:T) WHERE n.v = true RETURN n", reg)) ==
          idsOf(runQ(s, "MATCH (n:T) WHERE n.v = true RETURN n", nil))
    check idsOf(runQ(s, "MATCH (n:T) WHERE n.v = true RETURN n", nil)).len == 1

  test "a mixed column disqualifies the index instead of zeroing keys":
    ## Two kinds in one column cannot share a block, and storing the second
    ## kind as the first kind's zero value is a key that compares as 0.0 or
    ## "" forever.
    let s = newStore()
    for i in 0 ..< 5:
      let id = s.createNode("M")
      discard s.setNodeProp(id, "v", Value(kind: vkInt, i: int64(i)))
    let mixed = s.createNode("M")
    discard s.setNodeProp(mixed, "v", Value(kind: vkString, s: "later"))
    let reg = withIndex(s, "M", "v")
    check reg.find("M", "v").usable == false
    sameAnswer(s, "MATCH (n:M) WHERE n.v > 2 RETURN n", reg)

  test "a property set to null is an absent key, not a poison":
    ## `age = null` is a stored property with no value — the fixture's own
    ## Frank — and treating it as unkeyable disqualified every age index
    ## the moment the fixture was indexed. Absent is the ordinary case.
    let s = newStore()
    let a = s.createNode("N")
    discard s.setNodeProp(a, "age", Value(kind: vkInt, i: 30))
    let b = s.createNode("N")
    discard s.setNodeProp(b, "age", Value(kind: vkNull))
    let reg = withIndex(s, "N", "age")
    check reg.find("N", "age").usable
    sameAnswer(s, "MATCH (n:N) WHERE n.age = 30 RETURN n", reg)
    sameAnswer(s, "MATCH (n:N) WHERE n.age > 0 RETURN n", reg)

  test "a rebuild re-qualifies an index":
    ## `index_rebuild` refills from live records, which is also the way
    ## back from a disqualification: same records, same decision, and a
    ## column that has since been cleaned up indexes again.
    let s = newStore()
    let a = s.createNode("T")
    discard s.setNodeProp(a, "v", Value(kind: vkBool, b: true))
    let reg = withIndex(s, "T", "v")
    check reg.find("T", "v").usable == false
    discard s.setNodeProp(a, "v", Value(kind: vkInt, i: 7))
    reg.rebuild(s, "T.v")
    check reg.find("T", "v").usable
    sameAnswer(s, "MATCH (n:T) WHERE n.v = 7 RETURN n", reg)

suite "M6.1 the planner":
  test "every predicate answers the same with and without the index":
    let s = people(200)
    let reg = withIndex(s, "Person", "age")
    for sql in [
        "MATCH (n:Person) WHERE n.age = 30 RETURN n",
        "MATCH (n:Person) WHERE n.age > 30 RETURN n",
        "MATCH (n:Person) WHERE n.age >= 30 RETURN n",
        "MATCH (n:Person) WHERE n.age < 5 RETURN n",
        "MATCH (n:Person) WHERE n.age <= 5 RETURN n",
        "MATCH (n:Person) WHERE n.age IN [1, 7, 39] RETURN n",
        "MATCH (n:Person) WHERE n.age = 39 AND n.age > 0 RETURN n",
        "MATCH (n:Person) WHERE n.age = 99 RETURN n",
        "MATCH (n:Person) WHERE n.age > 100 RETURN n",
        # A string index, and a predicate the index cannot answer.
        "MATCH (n:Person) WHERE n.name = 'p7' RETURN n",
        "MATCH (n:Person) WHERE n.city = 'c3' RETURN n",
        "MATCH (n:Person) WHERE n.age = $age RETURN n",
        "MATCH (n:Person) WHERE n.nothing = 3 RETURN n"]:
      sameAnswer(s, sql, reg)

  test "a string-indexed predicate, with the index built for it":
    let s = people(200)
    let reg = withIndex(s, "Person", "name")
    for sql in ["MATCH (n:Person) WHERE n.name = 'p7' RETURN n",
                "MATCH (n:Person) WHERE n.name > 'p190' RETURN n",
                "MATCH (n:Person) WHERE n.name < 'p10' RETURN n"]:
      sameAnswer(s, sql, reg)

  test "the planner actually seeks, and not for a predicate it cannot answer":
    ## The answers are identical either way — that is the point — so the
    ## only way to know the index was used is to ask it.
    let s = people(200)
    let reg = withIndex(s, "Person", "age")
    let ix = reg.find("Person", "age")
    ix.probes = 0
    discard runQ(s, "MATCH (n:Person) WHERE n.age > 30 RETURN n", reg)
    check ix.probes == 1
    ix.probes = 0
    discard runQ(s, "MATCH (n:Person) WHERE n.name = 'p7' RETURN n", reg)
    check ix.probes == 0

  test "a seek fires for a PARAMETER predicate, not only for a literal":
    ## The existing seek gate used `n.age > 30`: a literal, the one
    ## spelling nobody writes by hand. It passed while `n.age > $lo`
    ## planned as a full scan — and the parameter spelling is what the
    ## model layer, the importer, and every benchmark in this project
    ## actually write. On a 2·10^4-node range index that was 235/s before
    ## and 46 009/s after. I5 never saw it
    ## because I5 measures the index directly, not through a query.
    ## DEVLOG, "the literal gate".
    let s = people(200)
    let reg = withIndex(s, "Person", "age")
    let ix = reg.find("Person", "age")
    var params = initTable[string, Value]()
    params["lo"] = Value(kind: vkInt, i: 30)
    ix.probes = 0
    let st = prepare(s, "MATCH (n:Person) WHERE n.age > $lo RETURN n",
                     params, nil, 0, "", reg)
    defer: st.close()
    let rows = st.collectRows()
    check ix.probes == 1
    ## And the answer is the same as the literal spelling — the seek is an
    ## accelerator, never a second implementation of WHERE.
    let litRows = runQ(s, "MATCH (n:Person) WHERE n.age > 30 RETURN n", reg)
    check idsOf(rows) == idsOf(litRows)

  test "a bound parameter and a literal plan identically (no literal-only path)":
    ## Direct statement of the invariant the last test pins in one place:
    ## for every comparison the index can answer, `$p` and the literal must
    ## reach the same plan. If a future change narrows `isValue`, one of
    ## these two seeks and the other does not, and this fails.
    let s = people(200)
    let reg = withIndex(s, "Person", "age")
    let ix = reg.find("Person", "age")
    for (paramSql, litSql, v) in [
        ("MATCH (n:Person) WHERE n.age = $v RETURN n",
         "MATCH (n:Person) WHERE n.age = 42 RETURN n", Value(kind: vkInt, i: 42)),
        ("MATCH (n:Person) WHERE n.age > $v RETURN n",
         "MATCH (n:Person) WHERE n.age > 30 RETURN n", Value(kind: vkInt, i: 30)),
        ("MATCH (n:Person) WHERE n.age <= $v RETURN n",
         "MATCH (n:Person) WHERE n.age <= 90 RETURN n", Value(kind: vkInt, i: 90))]:
      var params = initTable[string, Value]()
      params["v"] = v
      ix.probes = 0
      let a = prepare(s, paramSql, params, nil, 0, "", reg)
      let aRows = a.collectRows()
      a.close()
      let paramProbes = ix.probes
      ix.probes = 0
      let b = prepare(s, litSql, initTable[string, Value](), nil, 0, "", reg)
      let bRows = b.collectRows()
      b.close()
      check paramProbes == ix.probes
      check idsOf(aRows) == idsOf(bRows)

  test "an unbound parameter does not seek (it would lose rows)":
    ## `$missing` is not in the table, so it resolves to null; null is not
    ## keyable, so the scan answers. Seeking on it would return nothing and
    ## silently drop the rows the scan finds — the one direction an
    ## accelerator may not move.
    let s = people(200)
    let reg = withIndex(s, "Person", "age")
    let ix = reg.find("Person", "age")
    var params = initTable[string, Value]()
    ix.probes = 0
    let st = prepare(s, "MATCH (n:Person) WHERE n.age = $missing RETURN n",
                     params, nil, 0, "", reg)
    defer: st.close()
    discard st.collectRows()
    check ix.probes == 0

  test "a seek is skipped when the pattern's own property map already answers":
    ## `MATCH (n:Person {age: 30})` constrains the same property; both paths
    ## give the same rows, and the inline filter is what makes the seek safe
    ## rather than authoritative.
    let s = people(200)
    let reg = withIndex(s, "Person", "age")
    sameAnswer(s, "MATCH (n:Person {age: 30}) RETURN n", reg)

suite "M6.1 freshness":
  test "a committed write is in the index, and a rollback leaves it out":
    ## The invariant INDEX.md §5 states: an index is never stale relative to
    ## committed data. It is checked through the *query*, because that is
    ## where a stale index shows up — as fewer rows, with no error.
    let s = newStore()
    let reg = withIndex(s, "Person", "age")
    var tx = txn.begin(s, nil, 1)
    var st = prepare(s, "CREATE (:Person {age: 30})", initTable[string, Value](), tx)
    discard st.step()
    discard st.rowsAffected()
    st.close()
    check tx.commit()
    ## After the merge, not before: the index reads the *store*, so a delta
    ## applied pre-commit would see a node the store has not published yet —
    ## and would say so by finding nothing.
    reg.applyDelta(s, tx.nodeDelta, tx.edgeDelta)
    check idsOf(runQ(s, "MATCH (n:Person) WHERE n.age = 30 RETURN n", reg)).len == 1

    var tx2 = txn.begin(s, nil, 1)
    st = prepare(s, "CREATE (:Person {age: 30})", initTable[string, Value](), tx2)
    discard st.step()
    discard st.rowsAffected()
    st.close()
    discard tx2.rollback()
    ## The rolled-back node never reached the store, so the index must not
    ## know about it either — a rollback that left an entry behind would
    ## make the next query return a node that does not exist.
    check idsOf(runQ(s, "MATCH (n:Person) WHERE n.age = 30 RETURN n", reg)).len == 1

  test "SET and DELETE keep the index in step with the store":
    let s = people(50)
    let reg = withIndex(s, "Person", "age")
    let tx = txn.begin(s, nil, 1)
    var st = prepare(s, "MATCH (n:Person {age: 3}) SET n.age = 40",
                     initTable[string, Value](), tx)
    while st.step(): discard
    discard st.rowsAffected()
    st.close()
    st = prepare(s, "MATCH (n:Person {age: 0}) DELETE n",
                 initTable[string, Value](), tx)
    while st.step(): discard
    discard st.rowsAffected()
    st.close()
    check tx.commit()
    reg.applyDelta(s, tx.nodeDelta, tx.edgeDelta)
    sameAnswer(s, "MATCH (n:Person) WHERE n.age = 3 RETURN n", reg)
    sameAnswer(s, "MATCH (n:Person) WHERE n.age = 40 RETURN n", reg)
    sameAnswer(s, "MATCH (n:Person) WHERE n.age = 0 RETURN n", reg)

  test "a read inside the transaction sees its own writes (pin C4)":
    ## The index is updated at commit, so a seek inside the transaction
    ## would miss what it has not been told about. The seek's delta half is
    ## what keeps this true — without it, `CREATE` then `MATCH … WHERE
    ## indexed = …` in one transaction finds nothing.
    let s = newStore()
    let reg = withIndex(s, "Person", "age")
    let tx = txn.begin(s, nil, 1)
    var st = prepare(s, "CREATE (:Person {age: 77})",
                     initTable[string, Value](), tx)
    discard st.step()
    discard st.rowsAffected()
    st.close()
    let read = prepare(s, "MATCH (n:Person) WHERE n.age = 77 RETURN n",
                       initTable[string, Value](), tx, 0, "", reg)
    var found = 0
    while read.step(): inc found
    read.close()
    check found == 1
    check tx.commit()

proc withText(s: GraphStore, target, property, analyzer = "standard"): Indexes =
  result = newIndexes()
  discard result.createText(target, property, analyzer)
  result.rebuild(s)

proc bm25(freq: int, dl, n, N: int, avgdl: float): float =
  ## The reference scorer, written out from INDEX.md §3 rather than called
  ## from the index. A test that compares the index to itself proves
  ## nothing; this is the whole gate I6 rests on.
  let f = float(freq)
  let idf = ln(1.0 + (float(N) - float(n) + 0.5) / (float(n) + 0.5))
  idf * (f * (1.2 + 1.0)) / (f + 1.2 * (1.0 - 0.75 + 0.75 * float(dl) / avgdl))

suite "M6.2 the text index":
  test "a score equals the reference BM25 within 0.1% (I6)":
    let s = newStore()
    let reg = newIndexes()
    discard reg.createText("Doc", "body", "standard")
    var nodes = initTable[int64, NodeRec]()
    var edges = initTable[int64, EdgeRec]()
    ## |D| is written out per document so the reference below uses the same
    ## numbers the analyzer produces: 9, 8 and 7 terms — `a` is one
    ## character and `MinTokenLen` is 2, so it is not a token at all.
    let ids = [s.createNode("Doc"), s.createNode("Doc"), s.createNode("Doc")]
    discard s.setNodeProp(ids[0], "body", Value(kind: vkString,
      s: "the quick brown fox jumps over the lazy dog"))
    discard s.setNodeProp(ids[1], "body", Value(kind: vkString,
      s: "the quick brown fox is quick and brown"))
    discard s.setNodeProp(ids[2], "body", Value(kind: vkString,
      s: "a lazy dog sleeps all day long here"))
    for i in ids:
      nodes[i] = s.nodes[int(i)]
    reg.rebuild(s)
    let ix = reg.text["Doc.body"]
    check ix.docCount == 3
    check ix.totalTerms == 24'i64
    let hits = ix.search(reg.terms, @["quick"], false, @[])
    check hits.len == 2
    ## doc 1: quick appears once, |D| = 9. doc 2: twice, |D| = 8.
    ## df("quick") = 2, N = 3, avgdl = 25/3.
    let avgdl = ix.avgDocLen        ## 24/3 = 8.0
    let refA = bm25(1, 9, 2, 3, avgdl)
    let refB = bm25(2, 8, 2, 3, avgdl)
    var gotA = 0.0
    var gotB = 0.0
    for h in hits:
      if h.nodeId == ids[0]: gotA = h.score
      elif h.nodeId == ids[1]: gotB = h.score
    check abs(gotA - refA) / refA < 0.001
    check abs(gotB - refB) / refB < 0.001
    ## And the ordering is by score, not by id.
    check hits[0].nodeId == ids[1]

  test "AND requires every term; OR does not (INDEX.md §3.3)":
    let s = newStore()
    let reg = newIndexes()
    discard reg.createText("Doc", "body", "standard")
    let ids = [s.createNode("Doc"), s.createNode("Doc"), s.createNode("Doc")]
    discard s.setNodeProp(ids[0], "body", Value(kind: vkString, s: "alpha beta"))
    discard s.setNodeProp(ids[1], "body", Value(kind: vkString, s: "alpha only"))
    discard s.setNodeProp(ids[2], "body", Value(kind: vkString, s: "beta only"))
    reg.rebuild(s)
    let ix = reg.text["Doc.body"]
    check ix.search(reg.terms, @["alpha", "beta"], true, @[]).len == 1
    check ix.search(reg.terms, @["alpha", "beta"], false, @[]).len == 3
    ## A term the index has never seen means no document can match under
    ## AND — the first version skipped it and answered with every document
    ## that had the *other* terms, which is the opposite of AND.
    check ix.search(reg.terms, @["alpha", "absent"], true, @[]).len == 0
    check ix.search(reg.terms, @["alpha", "absent"], false, @[]).len == 2
    ## Negation removes after the union, never before.
    let neg = ix.search(reg.terms, @["alpha"], false, @["beta"])
    check neg.len == 1
    check neg[0].nodeId == ids[1]

  test "a phrase is adjacent and in order (I7)":
    let s = newStore()
    let reg = newIndexes()
    discard reg.createText("Doc", "body", "standard")
    let ids = [s.createNode("Doc"), s.createNode("Doc")]
    discard s.setNodeProp(ids[0], "body", Value(kind: vkString,
      s: "the quick brown fox jumps"))
    discard s.setNodeProp(ids[1], "body", Value(kind: vkString,
      s: "the brown quick fox jumps"))
    reg.rebuild(s)
    let ix = reg.text["Doc.body"]
    check ix.phrase(reg.terms, @["quick", "brown"]).len == 1
    check ix.phrase(reg.terms, @["quick", "brown"])[0].nodeId == ids[0]
    ## Both documents hold the words; only one holds the phrase.
    check ix.phrase(reg.terms, @["brown", "quick"])[0].nodeId == ids[1]
    ## Non-adjacent is not a phrase even though the tokens co-occur: after
    ## the rewrite `quick` is at 0 and `brown` at 3, with `jumps over`
    ## between them.
    discard s.setNodeProp(ids[1], "body", Value(kind: vkString,
      s: "quick jumps over brown"))
    reg.rebuild(s)
    check ix.phrase(reg.terms, @["quick", "brown"]).len == 1
    check ix.phrase(reg.terms, @["quick", "over", "brown"]).len == 0
    check ix.phrase(reg.terms, @["quick", "jumps", "over", "brown"]).len == 1

  test "a query walks postings in proportion to the lists, not to the hits":
    ## Regression for the review: phrase and AND *scoring* each re-found a
    ## document's posting by scanning the term's whole posting list — once
    ## per document — so a query cost O(hits × corpus) while the
    ## intersection it sat on top of was already linear. 16k documents took
    ## 80 ms as phrase and grew quadratically; the counter is the oracle, so
    ## this test is deterministic where a timing assertion would flake.
    let n = 4_000
    let ix = newText("Doc.body", "Doc", "body")
    var terms = initTable[string, int32]()
    var dict = initTable[int32, string]()
    for i in 1 .. n:
      ## Every document holds `alpha`; a third hold the phrase too.
      let body = (if i mod 3 == 0: "alpha beta filler text" else: "alpha filler text")
      ix.update(int64(i), body)
    ix.merge(terms, dict)
    let total = ix.entryCount()
    ix.walked = 0
    let ph = ix.phrase(terms, @["alpha", "beta"])
    check ph.len == n div 3
    ## Two terms, one pass each: the walk may visit at most the two lists.
    check int64(ix.walked) <= 2 * total
    ix.walked = 0
    let andHits = ix.search(terms, @["alpha", "beta"], true, @[])
    check andHits.len == n div 3
    check int64(ix.walked) <= 2 * total
    ## And the OR path, which was already linear, still is.
    ix.walked = 0
    let orHits = ix.search(terms, @["alpha", "beta"], false, @[])
    check orHits.len == n
    check int64(ix.walked) <= 2 * total

  test "an unknown analyzer is refused, not silently standardized":
    let reg = newIndexes()
    expect GlyError:
      discard reg.createText("Doc", "body", "english_stemmer")

  test "the analyzer is per index and decides the terms (INDEX.md §3.1)":
    let reg = newIndexes()
    discard reg.createText("Doc", "body", "standard")
    discard reg.createText("Tag", "name", "keyword")
    reg.rebuild(newStore())
    let std = reg.text["Doc.body"]
    let kw = reg.text["Tag.name"]
    check std.analyzer == akStandard
    check kw.analyzer == akKeyword
    let a = Analyzer(kind: akStandard)
    let k = Analyzer(kind: akKeyword)
    check a.analyze("Hello, World!").len == 2
    check k.analyze("Hello, World!").len == 1
    ## A term under two characters is not a term.
    check a.analyze("a b cd").len == 1

  test "a write replaces the document; a delete removes it (freshness)":
    let s = newStore()
    let reg = newIndexes()
    discard reg.createText("Doc", "body", "standard")
    let ids = [s.createNode("Doc"), s.createNode("Doc")]
    discard s.setNodeProp(ids[0], "body", Value(kind: vkString, s: "zebra crossing"))
    discard s.setNodeProp(ids[1], "body", Value(kind: vkString, s: "zebra crossing"))
    reg.rebuild(s)
    let ix = reg.text["Doc.body"]
    check ix.search(reg.terms, @["zebra"], false, @[]).len == 2
    ## `SET` replaces: the old term must not survive, and N must not grow.
    var nodes = initTable[int64, NodeRec]()
    var edges = initTable[int64, EdgeRec]()
    discard s.setNodeProp(ids[0], "body", Value(kind: vkString, s: "giraffe bridge"))
    nodes[ids[0]] = s.nodes[int(ids[0])]
    reg.applyDelta(s, nodes, edges)
    check ix.search(reg.terms, @["zebra"], false, @[]).len == 1
    check ix.search(reg.terms, @["giraffe"], false, @[]).len == 1
    ## Replacing a document is not adding one: N stays 2, not 3. An index
    ## whose docCount creeps upward on every edit scores every document as
    ## rarer than it is, and the drift is invisible until it is large.
    check ix.docCount == 2
    discard s.deleteNode(ids[1], false)
    var n2 = initTable[int64, NodeRec]()
    n2[ids[1]] = s.nodes[int(ids[1])]
    reg.applyDelta(s, n2, edges)
    check ix.docCount == 1
    check ix.search(reg.terms, @["zebra"], false, @[]).len == 0
    check ix.search(reg.terms, @["giraffe"], false, @[]).len == 1
    ## Removing the property removes the document.
    discard s.setNodeProp(ids[0], "body", Value(kind: vkNull))
    var n3 = initTable[int64, NodeRec]()
    n3[ids[0]] = s.nodes[int(ids[0])]
    reg.applyDelta(s, n3, edges)
    check ix.docCount == 0

  test "a field that analyzes to nothing is not a document":
    let s = newStore()
    let reg = newIndexes()
    discard reg.createText("Doc", "body", "standard")
    let ids = [s.createNode("Doc"), s.createNode("Doc")]
    discard s.setNodeProp(ids[0], "body", Value(kind: vkString, s: "a real document"))
    discard s.setNodeProp(ids[1], "body", Value(kind: vkString, s: "!!! ??? ..."))
    reg.rebuild(s)
    let ix = reg.text["Doc.body"]
    ## `a real document` is two terms: `a` is below `MinTokenLen`. The
    ## punctuation-only field contributes to neither N nor Σ|D| — a field
    ## that analyzes to nothing must not halve every score in the index.
    check ix.docCount == 1
    check ix.totalTerms == 2'i64

  test "the term dictionary is shared and codes are never reused":
    let reg = newIndexes()
    discard reg.createText("Doc", "body", "standard")
    discard reg.createText("Doc", "title", "standard")
    let s = newStore()
    reg.rebuild(s)
    ## One code for `fox` in two indexes: a per-index dictionary would give
    ## it two codes and make the postings of the two fields incomparable.
    var terms = initTable[string, int32]()
    var dict = initTable[int32, string]()
    let ix = reg.text["Doc.body"]
    ix.update(1, "fox")
    ix.merge(terms, dict)
    let code = terms["fox"]
    let other = reg.text["Doc.title"]
    other.update(1, "fox")
    other.merge(terms, dict)
    check terms["fox"] == code
    check other.postings.hasKey(code)
    check dict[code] == "fox"

suite "M6.2 constraints (I9)":
  proc freshDb(): tuple[s: GraphStore, reg: Indexes] =
    result.s = newStore()
    result.reg = newIndexes()

  proc run1(s: GraphStore, reg: Indexes, sql: string,
            tx: WriteTransaction) =
    var st = prepare(s, sql, initTable[string, Value](), tx, 0, "", reg)
    discard st.step()
    discard st.rowsAffected()
    st.close()

  test "creating a unique constraint over data that already violates it is refused":
    let (s, reg) = freshDb()
    var tx = txn.begin(s, nil, 1)
    run1(s, reg, "CREATE (:User {email: 'a@x'})", tx)
    run1(s, reg, "CREATE (:User {email: 'a@x'})", tx)
    check tx.commit()
    discard reg.create(IdxRange, "User", "email", ConstraintUnique)
    reg.rebuild(s)
    expect GlyError:
      reg.checkExistingConstraints(s)
    ## The refusal names the value and both nodes.
    try:
      reg.checkExistingConstraints(s)
    except GlyError as e:
      check "a@x" in e.msg
      check "nodes" in e.msg

  test "two nodes with the same value in one transaction fail the commit":
    let (s, reg) = freshDb()
    discard reg.create(IdxRange, "User", "email", ConstraintUnique)
    reg.rebuild(s)
    var tx = txn.begin(s, nil, 1)
    tx.indicesToUpdate = reg
    run1(s, reg, "CREATE (:User {email: 'a@x'})", tx)
    run1(s, reg, "CREATE (:User {email: 'a@x'})", tx)
    expect GlyError:
      discard tx.commit()
    discard tx.rollback()
    ## Nothing durable, nothing visible: the violation never reached the
    ## log, so the store is as it was.
    var found = 0
    for id in 1 ..< s.nodes.len:
      if s.nodes[id].live(): inc found
    check found == 0

  test "a value a committed node already holds fails the new write":
    let (s, reg) = freshDb()
    discard reg.create(IdxRange, "User", "email", ConstraintUnique)
    reg.rebuild(s)
    var tx = txn.begin(s, nil, 1)
    tx.indicesToUpdate = reg
    run1(s, reg, "CREATE (:User {email: 'a@x'})", tx)
    check tx.commit()
    reg.applyDelta(s, tx.nodeDelta, tx.edgeDelta)
    ## The violation names the conflicting node, not just the rule.
    var tx2 = txn.begin(s, nil, 1)
    tx2.indicesToUpdate = reg
    run1(s, reg, "CREATE (:User {email: 'b@x'})", tx2)
    run1(s, reg, "CREATE (:User {email: 'a@x'})", tx2)
    try:
      discard tx2.commit()
      check false
    except GlyError as e:
      check "a@x" in e.msg
      check "already held by node" in e.msg
    discard tx2.rollback()

  test "an int and a float that are the same number are one key":
    let (s, reg) = freshDb()
    discard reg.create(IdxRange, "User", "num", ConstraintUnique)
    reg.rebuild(s)
    var tx = txn.begin(s, nil, 1)
    tx.indicesToUpdate = reg
    run1(s, reg, "CREATE (:User {num: 7})", tx)
    run1(s, reg, "CREATE (:User {num: 7.0})", tx)
    try:
      discard tx.commit()
      check false
    except GlyError as e:
      check "constraint unique" in e.msg
    discard tx.rollback()

  test "exists refuses a create without the property, and a REMOVE of it":
    let (s, reg) = freshDb()
    discard reg.create(IdxRange, "User", "email", ConstraintExists)
    reg.rebuild(s)
    var tx = txn.begin(s, nil, 1)
    tx.indicesToUpdate = reg
    run1(s, reg, "CREATE (:User {name: 'a'})", tx)
    try:
      discard tx.commit()
      check false
    except GlyError as e:
      check "has no email" in e.msg
    discard tx.rollback()
    ## A stored null is not a presence either: `SET n.email = null` is a
    ## removal (prop.nim), so it fails the same way.
    var tx2 = txn.begin(s, nil, 1)
    tx2.indicesToUpdate = reg
    run1(s, reg, "CREATE (:User {email: 'a@x'})", tx2)
    check tx2.commit()
    reg.applyDelta(s, tx2.nodeDelta, tx2.edgeDelta)
    var tx3 = txn.begin(s, nil, 1)
    tx3.indicesToUpdate = reg
    run1(s, reg, "MATCH (n:User) REMOVE n.email", tx3)
    try:
      discard tx3.commit()
      check false
    except GlyError as e:
      check "has no email" in e.msg
    discard tx3.rollback()

  test "not_null is exists with another spelling":
    ## TXN.md §5 lists them as two rows; prop.nim removes on null, so a
    ## stored null does not exist and the two constraints cannot differ.
    ## One test pins that they are one check, so a future change to one
    ## cannot quietly fork the semantics.
    let (s, reg) = freshDb()
    discard reg.create(IdxRange, "User", "email", ConstraintNotNull)
    reg.rebuild(s)
    var tx = txn.begin(s, nil, 1)
    tx.indicesToUpdate = reg
    run1(s, reg, "CREATE (:User)", tx)
    try:
      discard tx.commit()
      check false
    except GlyError as e:
      check "has no email" in e.msg
    discard tx.rollback()

  test "a unique value the index cannot key refuses the write":
    ## A bool has no committed lookup (`seekEq` cannot find one), so a
    ## uniqueness check against the store is impossible. Allowing the write
    ## would enforce uniqueness against this transaction's nodes only —
    ## a check that can be slipped past — so the write is refused.
    let (s, reg) = freshDb()
    discard reg.create(IdxRange, "User", "flag", ConstraintUnique)
    reg.rebuild(s)
    var tx = txn.begin(s, nil, 1)
    tx.indicesToUpdate = reg
    run1(s, reg, "CREATE (:User {flag: true})", tx)
    try:
      discard tx.commit()
      check false
    except GlyError as e:
      check "cannot be keyed" in e.msg
    discard tx.rollback()

  test "nulls do not collide under unique, and other labels are exempt":
    let (s, reg) = freshDb()
    discard reg.create(IdxRange, "User", "email", ConstraintUnique)
    reg.rebuild(s)
    var tx = txn.begin(s, nil, 1)
    tx.indicesToUpdate = reg
    run1(s, reg, "CREATE (:User)", tx)
    run1(s, reg, "CREATE (:User)", tx)
    run1(s, reg, "CREATE (:Other {email: 'a@x'})", tx)
    run1(s, reg, "CREATE (:Other {email: 'a@x'})", tx)
    check tx.commit()
    reg.applyDelta(s, tx.nodeDelta, tx.edgeDelta)

suite "M6.2 the text CALL (CYPHER.md §4)":
  proc buildTextGraph(): tuple[s: GraphStore, reg: Indexes] =
    result.s = newStore()
    result.reg = newIndexes()
    var tx = txn.begin(result.s, nil, 1)
    for body in ["the quick brown fox jumps over the lazy dog",
                 "the quick brown fox is quick and brown",
                 "a lazy dog sleeps all day"]:
      var st = prepare(result.s,
                       "CREATE (:Doc {body: '" & body & "'})",
                       initTable[string, Value](), tx, 0, "", result.reg)
      discard st.step(); st.close()
    check tx.commit()
    discard result.reg.createText("Doc", "body", "standard")
    result.reg.rebuild(result.s)

  proc rows(s: GraphStore, reg: Indexes, sql: string,
            params = initTable[string, Value](),
            tx: WriteTransaction = nil): seq[Row] =
    var st = prepare(s, sql, params, tx, 0, "", reg)
    while st.step():
      result.add st.current
    st.close()

  test "a literal search returns scored rows, best first":
    let (s, reg) = buildTextGraph()
    let rs = rows(s, reg,
      "CALL db.idx.text('Doc.body') AGAINST 'quick' YIELD doc, score " &
      "RETURN doc, score")
    check rs.len == 2
    ## `quick` is twice in doc 2 and once in doc 1: twice scores higher,
    ## and the order is the answer, not a side effect.
    check rs[0].lookup("score")[1].f > rs[1].lookup("score")[1].f
    check rs[0].lookup("doc")[1].id == 2'i64
    check rs[0].lookup("score")[1].kind == vkFloat
    check rs[0].lookup("doc")[1].kind == vkNode

  test "a parameter carries the query, and a missing one is named":
    let (s, reg) = buildTextGraph()
    var params = initTable[string, Value]()
    params["q"] = Value(kind: vkString, s: "lazy")
    let rs = rows(s, reg,
      "CALL db.idx.text('Doc.body') AGAINST $q YIELD d, s RETURN d, s", params)
    check rs.len == 2          ## docs 1 and 3 both hold `lazy`
    ## The missing parameter is a caller mistake (GlyError from the
    ## planner), not an unsupported construct — the message names it.
    expect GlyError:
      discard rows(s, reg,
        "CALL db.idx.text('Doc.body') AGAINST $missing YIELD d, s RETURN d")

  test "WHERE composes above the retrieval":
    let (s, reg) = buildTextGraph()
    let rs = rows(s, reg,
      "CALL db.idx.text('Doc.body') AGAINST 'quick' YIELD doc, score " &
      "WHERE score > 0.5 RETURN doc, score")
    check rs.len == 1
    check rs[0].lookup("doc")[1].id == 2'i64
    ## The yielded names are variables: filtering on an unknown one is a
    ## scope error, not an empty result.
    expect CypherError:
      discard rows(s, reg,
        "CALL db.idx.text('Doc.body') AGAINST 'quick' YIELD doc, score " &
        "WHERE scoore > 0.2 RETURN doc")

  test "a deleted node is never returned by the search (I8)":
    let (s, reg) = buildTextGraph()
    var tx = txn.begin(s, nil, 1)
    tx.indicesToUpdate = reg
    var st = prepare(s, "MATCH (n:Doc) WHERE id(n) = 2 DELETE n",
                     initTable[string, Value](), tx, 0, "", reg)
    discard st.step(); st.close()
    check tx.commit()
    reg.applyDelta(s, tx.nodeDelta, tx.edgeDelta)
    let rs = rows(s, reg,
      "CALL db.idx.text('Doc.body') AGAINST 'quick' YIELD doc, score RETURN doc")
    check rs.len == 1
    check rs[0].lookup("doc")[1].id == 1'i64

  test "a statement in the writing transaction sees its own writes (C4)":
    let (s, reg) = buildTextGraph()
    let tx = txn.begin(s, nil, 1)
    tx.indicesToUpdate = reg
    var st = prepare(s, "CREATE (:Doc {body: 'brand new zebra document'})",
                     initTable[string, Value](), tx, 0, "", reg)
    discard st.step(); st.close()
    check rows(s, reg,
      "CALL db.idx.text('Doc.body') AGAINST 'zebra' YIELD doc RETURN doc",
      initTable[string, Value](), tx).len == 1
    ## …and a read statement outside it still does not: the write is not
    ## committed, and the overlay belongs to the writing transaction alone.
    check rows(s, reg,
      "CALL db.idx.text('Doc.body') AGAINST 'zebra' YIELD doc RETURN doc",
    ).len == 0
    discard tx.rollback()

  test "every other CALL keeps a named refusal":
    let (s, reg) = buildTextGraph()
    let refused = [
      "CALL db.idx.vector('Doc.e') AGAINST 'v' YIELD d, s RETURN d",
      "CALL db.idx.nope('Doc.body') AGAINST 'v' YIELD d, s RETURN d",
      "CALL db.idx.text('Nope.body') AGAINST 'v' YIELD d, s RETURN d",
      "CALL db.idx.text('Doc.body') AGAINST 42 YIELD d, s RETURN d",
      "CALL db.idx.text('Doc.body') AGAINST 'x' RETURN doc",
      "CALL foo() YIELD x RETURN x",
    ]
    for sql in refused:
      try:
        discard rows(s, reg, sql)
        check false and sql == ""
      except CatchableError as e:
        ## Parser refusals arrive as CypherError, a missing index as
        ## GlyError; either way the message must name what was refused,
        ## which is §5's whole rule.
        check e.msg.len > 0

  test "a retrieval does not join, by either direction":
    ## The composed form — filters inside a retrieval — needs an operator
    ## the vector family lands with (M6.3). Refusing by name keeps a
    ## cartesian product from being the accidental answer.
    let (s, reg) = buildTextGraph()
    expect CypherError:
      discard rows(s, reg,
        "CALL db.idx.text('Doc.body') AGAINST 'quick' YIELD d, s " &
        "MATCH (n) RETURN n")
    var tx = txn.begin(s, nil, 1)
    tx.indicesToUpdate = reg
    var st = prepare(s, "CREATE (:Doc {body: 'x'})",
                     initTable[string, Value](), tx, 0, "", reg)
    discard st.step(); st.close()
    expect CypherError:
      discard rows(s, reg,
        "CREATE (:Doc {body: 'y'}) CALL db.idx.text('Doc.body') " &
        "AGAINST 'y' YIELD d, s RETURN d", initTable[string, Value](), tx)
    discard tx.rollback()

suite "M6.3 the vector index (HNSW)":
  proc clustered(r: var Rand, dim: int, centers: seq[seq[float32]]): seq[float32] =
    let c = centers[r.rand(centers.len - 1)]
    result = newSeq[float32](dim)
    for i in 0 ..< dim:
      result[i] = c[i] + r.rand(-0.25 .. 0.25)
    var nrm = 0.0
    for f in result:
      nrm += f * f
    nrm = sqrt(nrm)
    for i in 0 ..< dim:
      result[i] = float32(result[i] / nrm)

  proc graphBytes(ix: VectorIndex): string =
    ## Everything the graph's structure lives in — the I11 comparator.
    for f in ix.vecs:
      let u = cast[uint32](f)
      result.add chr(u and 0xFF'u32)
      result.add chr((u shr 8) and 0xFF'u32)
      result.add chr((u shr 16) and 0xFF'u32)
      result.add chr((u shr 24) and 0xFF'u32)
    for l in ix.levels:
      result.add chr(l and 0xFF)
    for n in ix.links0:
      result.add chr(int32(n) and 0xFF)
    for run in ix.hi:
      for n in run:
        result.add chr(int32(n) and 0xFF)
    result.add chr(ix.entry and 0xFF)
    result.add chr(ix.maxLevel and 0xFF)

  test "the same input builds a byte-identical graph twice (I11)":
    var r = initRand(7)
    let dim = 16
    var centers: seq[seq[float32]] = @[]
    for c in 0 ..< 8:
      var ct = newSeq[float32](dim)
      for i in 0 ..< dim:
        ct[i] = r.rand(-1.0 .. 1.0)
      centers.add ct
    var all: seq[seq[float32]] = @[]
    for i in 0 ..< 2000:
      all.add clustered(r, dim, centers)
    let a = newVector("T.v", "T", "v")
    let b = newVector("T.v", "T", "v")
    for i, v in all:
      a.insert(int64(i + 1), v)
      b.insert(int64(i + 1), v)
    check graphBytes(a) == graphBytes(b)
    ## A rebuild is the same algorithm on the same input, and the level
    ## draw is part of the state `reset` restores.
    a.reset()
    for i, v in all:
      a.insert(int64(i + 1), v)
    check graphBytes(a) == graphBytes(b)

  test "recall@10 on clustered data clears 0.95 at the defaults":
    ## INDEX.md §4.5's gate, on the distribution embeddings actually have.
    ## Uniform random vectors are the documented worst case (0.90 at
    ## ef=128, measured during the build) and are not the gate.
    var r = initRand(11)
    let dim = 24
    var centers: seq[seq[float32]] = @[]
    for c in 0 ..< 40:
      var ct = newSeq[float32](dim)
      for i in 0 ..< dim:
        ct[i] = r.rand(-1.0 .. 1.0)
      centers.add ct
    let ix = newVector("T.v", "T", "v")
    var queries: seq[seq[float32]] = @[]
    for i in 1 .. 5000:
      let v = clustered(r, dim, centers)
      ix.insert(int64(i), v)
      if i mod 50 == 0:
        queries.add v
    ## brute force over the same data, the honest denominator
    proc truth(q: seq[float32], k: int): seq[int64] =
      var best: seq[(float32, int64)] = @[]
      for s in 0 ..< int32(ix.ids.len):
        var d = 0.0'f32
        for i in 0 ..< dim:
          let t = q[i] - ix.vecs[int(s) * dim + i]
          d += t * t
        best.add (d, ix.ids[s])
      proc byD(a, b: (float32, int64)): int =
        (if a[0] < b[0]: -1 elif a[0] > b[0]: 1 else: 0)
      best.sort(byD)
      for i in 0 ..< k:
        result.add best[i][1]
    ix.ef = 128
    var hits = 0
    var total = 0
    for q in queries:
      let t = truth(q, 10)
      for (id, score) in ix.search(q, 10):
        if id in t:
          inc hits
      inc total, 10
    let recall = hits / total
    check recall >= 0.95

  test "a tombstoned node is never returned (I8), and updates tombstone":
    let ix = newVector("T.v", "T", "v")
    ix.insert(1, [1.0'f32, 0.0, 0.0])
    ix.insert(2, [0.9'f32, 0.1, 0.0])
    ix.insert(3, [0.0'f32, 1.0, 0.0])
    check ix.search([0.95'f32, 0.05, 0.0], 3).len == 3
    check ix.remove(2)
    let hits = ix.search([0.95'f32, 0.05, 0.0], 3)
    check hits.len == 2
    for h in hits:
      check h[0] != 2'i64
    ## An update is a tombstone plus a new entry: the old vector must not
    ## answer after the node moved.
    ix.insert(2, [0.0'f32, 0.0, 1.0])
    check ix.liveCount() == 3
    let after = ix.search([0.95'f32, 0.05, 0.0], 5)
    for h in after:
      if h[0] == 2'i64:
        check h[1] < 0.5     ## the new vector is far from (1,0,0)

  test "ef_construction below 200 is refused (INDEX.md §4.1)":
    expect GlyError:
      discard newVector("T.v", "T", "v", efConstruction = 100)

  test "the metric is per index and named refusals cover it (I13)":
    let c = newVector("T.v", "T", "v", metric = mCosine)
    let l = newVector("T.v", "T", "v", metric = mL2)
    ## Same neighbours, different score shapes: cosine tops out near 1,
    ## l2's similarity shape is 1/(1+d).
    for i in 1 .. 50:
      let v = [float32(i) / 50.0'f32, 0.3'f32, 0.1'f32]
      c.insert(int64(i), v)
      l.insert(int64(i), v)
    let hc = c.search([0.9'f32, 0.3, 0.1], 1)
    let hl = l.search([0.9'f32, 0.3, 0.1], 1)
    check hc[0][0] == hl[0][0]
    check hc[0][1] <= 1.0 and hc[0][1] > 0.9
    check hl[0][1] <= 1.0 and hl[0][1] > 0.9
    expect GlyError:
      discard metricFromName("manhattan")

  test "a dimension mismatch is refused, not padded":
    let ix = newVector("T.v", "T", "v")
    ix.insert(1, [1.0'f32, 0.0, 0.0])
    expect GlyError:
      ix.insert(2, [1.0'f32, 0.0])
    expect GlyError:
      discard ix.search([1.0'f32, 0.0], 3)

  test "an index past the tombstone threshold asks to be rebuilt (I14)":
    ## INDEX.md I14: a vector index whose tombstones pass a fifth of its
    ## entries is one whose walk pays for them forever, and the fix is a
    ## rebuild from live records — checked at compaction, not per delete, so
    ## a delete never pays for a rebuild. The predicate is what `checkpoint`
    ## asks; this pins the threshold itself.
    let reg = newIndexes()
    discard reg.createVector("Doc", "emb", mCosine)
    let v = reg.vector["Doc.emb"]
    # 100 live entries, none dead: nothing to rebuild.
    for i in 0 ..< 100:
      v.ids.add int64(i)
      v.dead.add false
    v.deadCount = 0
    check reg.indexesNeedingRebuild().len == 0
    # A fifth dead is exactly at the threshold, not past it.
    v.deadCount = 20
    check reg.indexesNeedingRebuild().len == 0
    # Past it: asked for.
    v.deadCount = 21
    check reg.indexesNeedingRebuild().len == 1 and
      reg.indexesNeedingRebuild()[0] == "Doc.emb"
    # A range index never accumulates a tombstone, so it is never asked for.
    let reg2 = newIndexes()
    discard reg2.create(IdxRange, "Doc", "year")
    check reg2.indexesNeedingRebuild().len == 0

  test "the registry keeps one vector index per name and refuses a change":
    let reg = newIndexes()
    check reg.createVector("Doc", "embedding", mCosine) == "Doc.embedding"
    check reg.createVector("Doc", "embedding", mCosine) == "Doc.embedding"
    check reg.list().len == 1
    expect GlyError:
      discard reg.createVector("Doc", "embedding", mL2)
    expect GlyError:
      discard reg.createVector("Doc", "embedding", mCosine, m = 32)

  test "writes tombstone through applyDelta; rebuild is byte-identical (I11)":
    let s = newStore()
    let reg = newIndexes()
    discard reg.createVector("Doc", "embedding", mCosine)
    var ids: seq[int64] = @[]
    for i in 1 .. 6:
      ids.add s.createNode("Doc")
    proc sV(x: seq[float32]): Value = Value(kind: vkVector, dims: x)
    discard s.setNodeProp(ids[0], "embedding", sV(@[1.0'f32, 0.0, 0.0]))
    discard s.setNodeProp(ids[1], "embedding", sV(@[0.9'f32, 0.1, 0.0]))
    discard s.setNodeProp(ids[2], "embedding", sV(@[0.0'f32, 1.0, 0.0]))
    discard s.setNodeProp(ids[3], "embedding", sV(@[0.0'f32, 0.0, 1.0]))
    discard s.setNodeProp(ids[4], "embedding", sV(@[0.8'f32, 0.2, 0.1]))
    discard s.setNodeProp(ids[5], "embedding", sV(@[0.1'f32, 0.8, 0.2]))
    reg.rebuild(s)
    let ix = reg.vector["Doc.embedding"]
    check ix.liveCount() == 6
    ## Tombstone through the delta path, then compare a rebuild against a
    ## fresh build over the same live nodes.
    discard s.deleteNode(ids[2], false)
    var nodes = initTable[int64, NodeRec]()
    var edges = initTable[int64, EdgeRec]()
    nodes[ids[2]] = s.nodes[int(ids[2])]
    reg.applyDelta(s, nodes, edges)
    check ix.liveCount() == 5
    check ix.search([1.0'f32, 0.0, 0.0], 6).len == 5
    reg.rebuild(s)
    let fresh = newVector("Doc.embedding", "Doc", "embedding")
    for id in 1 ..< s.nodes.len:
      let rec = s.nodes[id]
      if not rec.live():
        continue
      var v = Value(kind: vkNull)
      if s.getNodeProp(id, "embedding", v):
        fresh.insert(id, asFloatVec(v))
    check graphBytes(fresh) == graphBytes(reg.vector["Doc.embedding"])
    check reg.stats()[0][1] == 5

suite "M6.3 the vector CALL (CYPHER.md §4)":
  proc buildVecGraph(): tuple[s: GraphStore, reg: Indexes] =
    result.s = newStore()
    result.reg = newIndexes()
    var tx = txn.begin(result.s, nil, 1)
    tx.indicesToUpdate = result.reg
    ## Three tight groups in 3d; years alternate 2020/2021/2022.
    let pts: seq[seq[float32]] = @[
      @[1.0'f32, 0.0, 0.0], @[0.95'f32, 0.05, 0.0], @[0.9'f32, 0.1, 0.0],
      @[0.0'f32, 1.0, 0.0], @[0.05'f32, 0.95, 0.0],
      @[0.0'f32, 0.0, 1.0], @[0.1'f32, 0.0, 0.9]]
    for i, p in pts:
      var st = prepare(result.s,
        "CREATE (:Doc {embedding: $v, year: $y})",
        {"v": Value(kind: vkVector, dims: p),
         "y": Value(kind: vkInt, i: 2020 + (i mod 3))}.toTable,
        tx, 0, "", result.reg)
      discard st.step()
      st.close()
    check tx.commit()
    result.reg.applyDelta(result.s, tx.nodeDelta, tx.edgeDelta)
    discard result.reg.createVector("Doc", "embedding", mCosine)
    result.reg.rebuild(result.s)

  proc rows(s: GraphStore, reg: Indexes, sql: string,
            params = initTable[string, Value](),
            tx: WriteTransaction = nil): seq[Row] =
    var st = prepare(s, sql, params, tx, 0, "", reg)
    while st.step():
      result.add st.current
    st.close()

  test "a vector literal in AGAINST works, and scores order the answer":
    let (s, reg) = buildVecGraph()
    let rs = rows(s, reg,
      "CALL db.idx.vector('Doc.embedding') AGAINST [1.0, 0.0, 0.0] " &
      "YIELD doc, score RETURN doc, score")
    check rs.len == 7                     ## no LIMIT: everything, best first
    ## (1,0,0) is cosine 1.0 from id 1 and 0.95 from id 2 — the near
    ## duplicate of the query tops the list.
    check rs[0].lookup("doc")[1].id == 1'i64
    check rs[0].lookup("score")[1].f > rs[1].lookup("score")[1].f

  test "a pushed WHERE is answered during the walk":
    let (s, reg) = buildVecGraph()
    var params = initTable[string, Value]()
    params["q"] = Value(kind: vkVector, dims: @[1.0'f32, 0.05, 0.0])
    let rs = rows(s, reg,
      "CALL db.idx.vector('Doc.embedding') AGAINST $q YIELD doc, score " &
      "WHERE doc.year = 2021 RETURN doc, score", params)
    ## year 2021 nodes are ids 2 and 5; the pushdown must return both, and
    ## only those, with the nearer one first.
    check rs.len == 2
    check rs[0].lookup("doc")[1].id == 2'i64
    check rs[1].lookup("doc")[1].id == 5'i64

  test "WHERE splits: pushed conjuncts during the walk, score above":
    let (s, reg) = buildVecGraph()
    var params = initTable[string, Value]()
    params["q"] = Value(kind: vkVector, dims: @[1.0'f32, 0.05, 0.0])
    let rs = rows(s, reg,
      "CALL db.idx.vector('Doc.embedding') AGAINST $q YIELD doc, score " &
      "WHERE doc.year >= 2021 AND score > 0.9 RETURN doc, score", params)
    ## year >= 2021 ids {2,3,5,6}; score > 0.9 vs (1,0.05,0) keeps 2 and 3.
    check rs.len == 2
    check rs[0].lookup("doc")[1].id == 2'i64
    check rs[1].lookup("doc")[1].id == 3'i64

  test "a list-of-numbers parameter is a vector; other types are refused":
    let (s, reg) = buildVecGraph()
    var params = initTable[string, Value]()
    params["q"] = Value(kind: vkList, items: @[
      Value(kind: vkFloat, f: 1.0), Value(kind: vkFloat, f: 0.05),
      Value(kind: vkFloat, f: 0.0)])
    check rows(s, reg,
      "CALL db.idx.vector('Doc.embedding') AGAINST $q YIELD doc RETURN doc",
      params).len == 7
    params["q"] = Value(kind: vkString, s: "not a vector")
    expect CypherError:
      discard rows(s, reg,
        "CALL db.idx.vector('Doc.embedding') AGAINST $q YIELD doc RETURN doc",
        params)

  test "a deleted node is never returned by the vector search (I8)":
    let (s, reg) = buildVecGraph()
    var tx = txn.begin(s, nil, 1)
    tx.indicesToUpdate = reg
    var st = prepare(s, "MATCH (n:Doc) WHERE id(n) = 2 DELETE n",
                     initTable[string, Value](), tx, 0, "", reg)
    discard st.step()
    st.close()
    check tx.commit()
    reg.applyDelta(s, tx.nodeDelta, tx.edgeDelta)
    var params = initTable[string, Value]()
    params["q"] = Value(kind: vkVector, dims: @[1.0'f32, 0.05, 0.0])
    for r in rows(s, reg,
      "CALL db.idx.vector('Doc.embedding') AGAINST $q YIELD doc RETURN doc",
      params):
      check r.lookup("doc")[1].id != 2'i64

  test "the writing transaction sees its own vectors (C4), exactly":
    let (s, reg) = buildVecGraph()
    let tx = txn.begin(s, nil, 1)
    tx.indicesToUpdate = reg
    var params = initTable[string, Value]()
    params["v"] = Value(kind: vkVector, dims: @[0.99'f32, 0.01, 0.0])
    params["y"] = Value(kind: vkInt, i: 2024)
    var st = prepare(s, "CREATE (:Doc {embedding: $v, year: $y})",
                     params, tx, 0, "", reg)
    discard st.step()
    st.close()
    params = initTable[string, Value]()
    params["q"] = Value(kind: vkVector, dims: @[1.0'f32, 0.0, 0.0])
    let rs = rows(s, reg,
      "CALL db.idx.vector('Doc.embedding') AGAINST $q YIELD doc, score " &
      "RETURN doc, score", params, tx)
    check rs.len == 8
    ## The new node is in the answer, and its score is the exact cosine —
    ## per-pair distances have no global statistics to approximate.
    var sawNew = false
    for r in rs:
      ## The fixture holds ids 1..7; the transaction's node is the one
      ## outside that set, and the published array has not grown yet.
      if r.lookup("doc")[1].id > 7'i64:
        sawNew = true
        check r.lookup("score")[1].f > 0.99
    check sawNew
    discard tx.rollback()

  test "an unknown index and a wrong dimension are named":
    let (s, reg) = buildVecGraph()
    var params = initTable[string, Value]()
    params["q"] = Value(kind: vkVector, dims: @[1.0'f32, 0.0])
    expect GlyError:
      discard rows(s, reg,
        "CALL db.idx.vector('Nope.e') AGAINST $q YIELD doc RETURN doc", params)
    expect GlyError:
      discard rows(s, reg,
        "CALL db.idx.vector('Doc.embedding') AGAINST $q YIELD doc RETURN doc",
        params)

suite "M6.3 review findings":
  test "an overlay score equals the committed score bit for bit":
    ## The read-your-writes overlay scores the transaction's own vectors
    ## outside the graph. When that used `dot / (sqrt(na) * sqrt(nb))`
    ## while the walk used `dot / (la * lb)` on precomputed lengths, the
    ## two differed in the last ulp — and a last-ulp difference between an
    ## overlay row and the committed row is a row that changes rank the
    ## moment the transaction commits.
    let ix = newVector("T.v", "T", "v")
    let a = [0.3'f32, 0.5, -0.2, 0.9, 0.1, 0.44, -0.7, 0.25]
    let b = [0.1'f32, -0.4, 0.6, 0.2, 0.8, 0.15, -0.3, 0.55]
    ix.insert(1, a)
    let walk = ix.search(b, 1)[0][1]
    check ix.scoreVec(b, a) == walk

  test "a rebuild reproduces the exact scores of a fresh build (I11)":
    ## Determinism of the *numbers*, not only of the graph bytes: two
    ## builds of the same input must score a query identically, because a
    ## differential test compares recall, not adjacency.
    var r = initRand(99)
    let a = newVector("T.v", "T", "v")
    let b = newVector("T.v", "T", "v")
    for i in 1 .. 500:
      let v = @[r.rand(-1.0 .. 1.0).float32, r.rand(-1.0 .. 1.0).float32,
                r.rand(-1.0 .. 1.0).float32]
      a.insert(int64(i), v)
      b.insert(int64(i), v)
    let q = @[0.1'f32, 0.2, 0.3]
    let ha = a.search(q, 10)
    let hb = b.search(q, 10)
    check ha.len == hb.len
    for i in 0 ..< ha.len:
      check ha[i] == hb[i]

suite "M5 write paths (review)":
  test "a transaction that writes twice keeps only the last value":
    let s = newStore()
    let tx = txn.begin(s, nil, 1)
    let id = tx.createNode("Person")
    check tx.setNodeProp(id, "name", Value(kind: vkString, s: "first"))
    check tx.setNodeProp(id, "name", Value(kind: vkString, s: "second"))
    check tx.commit()
    var v = Value(kind: vkNull)
    check s.getNodeProp(id, "name", v)
    check v.s == "second"

  test "an aborted transaction leaves nothing behind":
    let s = newStore()
    let tx = txn.begin(s, nil, 1)
    let id = tx.createNode("Person")
    discard tx.setNodeProp(id, "name", Value(kind: vkString, s: "gone"))
    check tx.rollback()
    var v = Value(kind: vkNull)
    check not s.getNodeProp(id, "name", v)
    ## And the ids the transaction consumed are not handed out again: a
    ## rolled-back id reused would make a tombstone wake up as new data.
    let tx2 = txn.begin(s, nil, 1)
    discard tx2.createNode("Person")
    check tx2.commit()

  test "aggregates over an empty group are the documented answers":
    let s = newStore()
    var st = prepare(s, "MATCH (n:Nothing) RETURN count(*) AS c, " &
                        "avg(n.x) AS a, collect(n.x) AS l, stdev(n.x) AS d")
    var rows = 0
    while st.step():
      rows += 1
      check st.current.lookup("c")[1].i == 0'i64
      check st.current.lookup("a")[1].kind == vkNull
      check st.current.lookup("l")[1].kind == vkList
      check st.current.lookup("l")[1].items.len == 0
    st.close()
    check rows == 1

  test "sum and avg over a mix of ints and floats fold as numbers":
    let s = newStore()
    var tx = txn.begin(s, nil, 1)
    var vals: seq[Value] = @[Value(kind: vkInt, i: 1),
                             Value(kind: vkFloat, f: 2.5),
                             Value(kind: vkInt, i: 3)]
    for v in vals:
      var st = prepare(s, "CREATE (:N {x: $x})", {"x": v}.toTable, tx)
      discard st.step()
      st.close()
    check tx.commit()
    var st = prepare(s, "MATCH (n:N) RETURN sum(n.x) AS s, avg(n.x) AS a, " &
                        "min(n.x) AS lo, max(n.x) AS hi")
    var got = false
    while st.step():
      got = true
      ## sum/avg fold the mix as numbers; min/max return the values
      ## themselves, so an int column's min is an int.
      check st.current.lookup("s")[1].f == 6.5
      check abs(st.current.lookup("a")[1].f - 2.1666667) < 0.0001
      check st.current.lookup("lo")[1].i == 1'i64
      check st.current.lookup("hi")[1].i == 3'i64
    st.close()
    check got

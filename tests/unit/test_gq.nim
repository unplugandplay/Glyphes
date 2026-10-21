## glyphes — GLYPH QUERY: the compiler and its refusals.
##
## The language is a *surface* over Cypher (PRD-GLYPH-QUERY.md, pin GQ1),
## so the tests are of two kinds:
##
## - **the compilation**, checked against the table in the PRD: every
##   statement compiles to the Cypher the table claims, byte for byte. A
##   golden file per statement would be a lot of files; a table is the
##   same statement in a form a reader can check.
## - **the differential**: the compiled statement returns the same rows
##   as the hand-written Cypher, over a fixture with labels, properties,
##   edges in both directions, and a node with no edges.
##
## And the two rules that make the language safe to expose: a value is
## never text, and every refusal names the construct.

import std/[unittest, tables, strutils]
import ../../src/store/store
import ../../src/store/prop
import ../../src/cypher/expr
import ../../src/cypher/ctx
import ../../src/cypher/execute
import ../../src/gq

# ------------------------------------------------------------- helpers

proc seed(): GraphStore =
  ## The same fixture the query suite uses, because a differential test
  ## against a hand-written query only means something on a graph with
  ## edges in both directions and a node with none.
  ##
  ##   1 Ana   :Person  age 34
  ##   2 Bo    :Person  age 41
  ##   3 Cleo  :Person  age 27
  ##   4 Acme  :Company
  ##   1->2 KNOWS
  ##   2->3 KNOWS
  result = newStore()
  let ana = result.createNode("Person")
  let bo = result.createNode("Person")
  let cleo = result.createNode("Person")
  let acme = result.createNode("Company")
  discard result.setNodeProp(ana, "age", Value(kind: vkInt, i: 34))
  discard result.setNodeProp(bo, "age", Value(kind: vkInt, i: 41))
  discard result.setNodeProp(cleo, "age", Value(kind: vkInt, i: 27))
  discard result.createEdge(ana, bo, "KNOWS")
  discard result.createEdge(bo, cleo, "KNOWS")
  discard result.createEdge(bo, acme, "WORKS_AT")

proc run(s: GraphStore, sql: string, params = initTable[string, Value]()): seq[Row] =
  let st = prepare(s, sql, params)
  defer: st.close()
  st.collectRows()

proc refusal(line: string): string =
  ## What the compiler said about a line it refused, or "" if it did
  ## not refuse it.
  try:
    discard compileGq(line)
    ""
  except GqError as e:
    e.msg

proc ids(rows: seq[Row]): seq[int64] =
  for r in rows:
    let (_, v) = r.lookup("id")
    if v.kind == vkInt: result.add v.i
    elif v.kind == vkNode: result.add v.id

suite "GLYPH QUERY — the compilation":

  test "find compiles to a labelled scan":
    let p = compileGq("find person")
    check p.kind == gpkQuery
    check p.cypher == "MATCH (n:person) RETURN id(n) AS id"
    check p.params.len == 0

  test "a where clause is the engine's, with bare properties rewritten":
    let p = compileGq("find person where age > 30")
    check p.cypher == "MATCH (n:person) WHERE n.age > 30 RETURN id(n) AS id"

  test "the rewrite leaves the rest of the clause alone":
    ## A float, a string with an escape, and a function call are all
    ## things the rewrite must not touch: it inserts a prefix at a
    ## position and changes nothing else.
    let p = compileGq("find person where age > 30.5 and name = \"O\\\"Hara\"")
    ## The clause keeps the client's own spelling — including the case of
    ## its operators: the rewrite inserts a prefix and changes nothing
    ## else, so "and" stays "and".
    check p.cypher ==
      "MATCH (n:person) WHERE n.age > 30.5 and n.name = \"O\\\"Hara\" RETURN id(n) AS id"

  test "a function call is not a property":
    let p = compileGq("find person where toLower(name) = \"ana\"")
    check p.cypher ==
      "MATCH (n:person) WHERE toLower(n.name) = \"ana\" RETURN id(n) AS id"

  test "go compiles to a chain, forward or back":
    check compileGq("go KNOWS").cypher ==
      "MATCH (a)-[:KNOWS]->(b) RETURN id(b) AS id"
    check compileGq("go back KNOWS").cypher ==
      "MATCH (a)-[:KNOWS]->(b) RETURN id(a) AS id"

  test "go from a parameter keeps the parameter":
    let p = compileGq("go knows from $p")
    check p.cypher ==
      "MATCH (a)-[:knows]->(b) WHERE id(a) = $p RETURN id(b) AS id"

  test "count compiles to the aggregate":
    check compileGq("count person").cypher ==
      "MATCH (n:person) RETURN count(n) AS n"

  test "labels is the schema door, not a query":
    check compileGq("labels").kind == gpkLabels

  test "add compiles to a create, with the values as parameters":
    let p = compileGq("add person {name \"Ada\", age 36}")
    check p.cypher == "CREATE (n:person {name: $p1, age: $p2})"
    check p.params.len == 2
    check p.params["p1"].kind == vkString
    check p.params["p1"].s == "Ada"
    check p.params["p2"].kind == vkInt
    check p.params["p2"].i == 36

  test "set and drop compile to a matched write":
    check compileGq("set $n age = 36").cypher ==
      "MATCH (n) WHERE id(n) = $n SET n.age = $p1"
    check compileGq("drop $n").cypher ==
      "MATCH (n) WHERE id(n) = $n DETACH DELETE n"

  test "link is the one statement that is not a query":
    let p = compileGq("link $a knows $b")
    check p.kind == gpkLink
    check p.linkType == "knows"
    check p.linkFrom == "$a"
    check p.linkTo == "$b"

suite "GLYPH QUERY — the rules that make it safe":

  test "a value never reaches the query text":
    ## The value carries a quote and a semicolon. If any of it reached
    ## the compiled Cypher, the compiled text would not be a fixed
    ## string — and a language whose values land in its text is an
    ## injection waiting for a name.
    let p = compileGq("add person {name \"Ada\\\"; DROP\"}")
    check p.cypher == "CREATE (n:person {name: $p1})"
    check "DROP" notin p.cypher
    check p.params["p1"].s == "Ada\"; DROP"

  test "a label or a type with punctuation in it is refused":
    ## The one place where client text becomes part of a query, so it is
    ## checked rather than trusted.
    ## The engine's own lexer refuses a malformed string first, so the
    ## refusal is the engine's — which is the right status for it.
    expect CatchableError:
      discard compileGq("find per\"son")
    expect CatchableError:
      discard compileGq("go kn\"ows")

suite "GLYPH QUERY — the refusals":

  test "every bad line says what was wrong":
    ## The table in the PRD. A refusal that does not name the construct
    ## is a refusal the caller cannot act on.
    check "unknown command 'goe'" in refusal("goe knows")
    check "expected a label" in refusal("find 42")
    check "expected a relationship type" in refusal("go")
    check "expected a node reference" in refusal("go knows from ada")
    check "one line" in refusal("find person\nfind person")
    check "after the statement" in refusal("find person extra")
    check "empty statement" in refusal("   ")

suite "GLYPH QUERY — the differential":

  test "a compiled statement returns what the hand-written query returns":
    ## The gate that keeps GLYPH QUERY honest (GQ-B): the same question,
    ## asked two ways, answered the same way.
    let s = seed()
    let pairs = [
      ("find Person", "MATCH (n:Person) RETURN id(n) AS id"),
      ("find Person where age > 30", "MATCH (n:Person) WHERE n.age > 30 RETURN id(n) AS id"),
      ("go KNOWS", "MATCH (a)-[:KNOWS]->(b) RETURN id(b) AS id"),
      ("go back KNOWS", "MATCH (a)-[:KNOWS]->(b) RETURN id(a) AS id"),
      ("count Person", "MATCH (n:Person) RETURN count(n) AS n"),
    ]
    for (gq, cypher) in pairs:
      let compiled = compileGq(gq)
      let a = ids(run(s, compiled.cypher, compiled.params))
      let b = ids(run(s, cypher))
      check a.len == b.len
      for i in 0 ..< a.len:
        check a[i] == b[i]

  test "the compiled statement really runs":
    ## Not a compile check: the rows come back.
    let s = seed()
    let p = compileGq("find Person where age > 30")
    let rows = run(s, p.cypher, p.params)
    check rows.len == 2

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

import std/[unittest, tables, strutils, os]
import ../../src/store/store
import ../../src/store/prop
import ../../src/cypher/expr
import ../../src/cypher/ctx
import ../../src/cypher/execute
import ../../src/gq
import ../../src/abi
import ../../src/errors
import ../../src/glyphes

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
    check p.cypher == "CREATE (n:person {name: $p1, age: $p2}) RETURN id(n) AS id"
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
    check p.cypher == "CREATE (n:person {name: $p1}) RETURN id(n) AS id"
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


# ------------------------------------------------------------- the doors
#
# The doors are what a client outside the process actually calls: the
# C ABI. The compiler tests above are the language; these are the
# surface a host reaches for.

var abiCounter = 0

proc abiPath(name: string): string =
  ## A path in the scratch directory, unique per call.
  inc abiCounter
  let p = "tmp" / ("gq-abi-" & $getCurrentProcessId() & "-" & $abiCounter &
                   "-" & name & ".glyph")
  removeFile(p)
  removeFile(p & "-wal")
  result = p

proc openAbi(path: string): GlyHandle =
  ## Through the exported proc, not `openDatabase`: the handle encoding
  ## and the registration are part of what is under test.
  var h: GlyHandle
  let status = glyphes_open(path.cstring, int32(GLY_OPEN_CREATE), addr h)
  if status != 0:
    raise newException(AssertionDefect,
      "glyphes_open -> " & $status & ": " & globalErrorMsg())
  h

proc cellInt(c: ptr GlyCell): int64 =
  ## An integer cell, read the way a host reads one: the value is in the
  ## cell's payload word, and the Ruby binding reads the same word (the
  ## cells are write-only from the host's side — ABI.md §2).
  check c[].tag == uint32(ord(glyInt))
  result = cast[int64](c[].aux)

suite "GLYPH QUERY — the doors":

  test "the compile door returns the Cypher and the parameters":
    var cypher = newString(256)
    var pjson = newString(256)
    var clen: csize_t = 0
    var plen: csize_t = 0
    let status = glyphes_gq_compile("add person {name \"Ada\"}".cstring,
                                    nil, addr cypher[0], csize_t(cypher.len),
                                    addr clen, addr pjson[0], csize_t(pjson.len),
                                    addr plen)
    check status == 0
    check cypher[0 ..< int(clen) - 1] == "CREATE (n:person {name: $p1}) RETURN id(n) AS id"
    check pjson[0 ..< int(plen) - 1] == "{\"p1\":\"Ada\"}"

  test "the compile door reports the length before the buffer is big enough":
    ## The cap protocol: ask with no buffer, get the length, ask again.
    var clen: csize_t = 0
    var plen: csize_t = 0
    let status = glyphes_gq_compile("find person".cstring, nil,
                                    nil, 0, addr clen, nil, 0, addr plen)
    check status == int32(glyMore)
    check clen > 0

  test "a client's value travels as a parameter, never as text":
    ## The door takes the client's values as JSON and puts them in the
    ## parameters — the compiled text is the same whatever the value is.
    var cypher = newString(256)
    var pjson = newString(256)
    var clen: csize_t = 0
    var plen: csize_t = 0
    let status = glyphes_gq_compile("find person where name = $who".cstring,
                                    "{\"who\": \"Ada\\\"; DROP\"}".cstring,
                                    addr cypher[0], csize_t(cypher.len),
                                    addr clen, addr pjson[0], csize_t(pjson.len),
                                    addr plen)
    check status == 0
    check cypher[0 ..< int(clen) - 1] ==
      "MATCH (n:person) WHERE n.name = $who RETURN id(n) AS id"
    check "DROP" notin cypher[0 ..< int(clen) - 1]

  test "a prepared GLYPH QUERY statement returns the rows":
    let path = abiPath("prepare")
    let dbh = openAbi(path)
    var n: int64 = 0
    var created: int64 = 0
    check glyphes_exec_returning(dbh,
      "CREATE (n:person {name: \"Ana\"}) RETURN id(n) AS id".cstring, nil, addr n,
      addr created) == 0
    check created > 0

    var stmt: GlyHandle
    check glyphes_gq_prepare(dbh, "find person".cstring, nil, addr stmt) == 0
    var cells: array[4, GlyCell]
    var rows: csize_t = 0
    let status = glyphes_gq_step(stmt, addr cells[0], csize_t(cells.len),
                                 addr rows)
    check status == int32(glyMore) or status == int32(glyDone)
    check rows == 1
    check cellInt(addr cells[0]) == created
    discard glyphes_stmt_close(stmt)
    discard glyphes_close(dbh)

  test "the doors refuse what is not a query, and say where to go":
    let path = abiPath("refuse")
    let dbh = openAbi(path)
    var stmt: GlyHandle
    check glyphes_gq_prepare(dbh, "labels".cstring, nil, addr stmt) != 0
    check "schema" in globalErrorMsg()
    check glyphes_gq_prepare(dbh, "link $a KNOWS $b".cstring, nil,
                             addr stmt) != 0
    check "glyphes_link" in globalErrorMsg()
    discard glyphes_close(dbh)

  test "the link door writes one edge, and it survives a reopen":
    ## The edge goes through the transaction, so it is in the log — an
    ## edge that a restart forgets is not an edge.
    let path = abiPath("link")
    let dbh = openAbi(path)
    var n: int64 = 0
    var ana: int64 = 0
    var bo: int64 = 0
    check glyphes_exec_returning(dbh, "CREATE (n:person {name: \"Ana\"}) RETURN id(n) AS id".cstring,
                                 nil, addr n, addr ana) == 0
    check glyphes_exec_returning(dbh, "CREATE (n:person {name: \"Bo\"}) RETURN id(n) AS id".cstring,
                                 nil, addr n, addr bo) == 0
    var edgeId: int64 = 0
    check glyphes_link(dbh, ana, "KNOWS".cstring, bo, addr edgeId) == 0
    check edgeId > 0
    discard glyphes_close(dbh)

    let dbh2 = openAbi(path)
    var stmt: GlyHandle
    check glyphes_gq_prepare(dbh2, "go KNOWS from $p".cstring,
                             ("{\"p\": " & $ana & "}").cstring, addr stmt) == 0
    var cells: array[4, GlyCell]
    var rows: csize_t = 0
    discard glyphes_gq_step(stmt, addr cells[0], csize_t(cells.len), addr rows)
    check rows == 1
    check cellInt(addr cells[0]) == bo
    discard glyphes_stmt_close(stmt)
    discard glyphes_close(dbh2)

  test "link_props writes edge properties in the same crossing":
    ## The bulk loader path: 10^6 edges cannot afford a MATCH/SET per edge.
    let path = abiPath("link_props")
    let dbh = openAbi(path)
    var n: int64 = 0
    var ana: int64 = 0
    var bo: int64 = 0
    check glyphes_exec_returning(dbh, "CREATE (n:person) RETURN id(n) AS id".cstring,
                                 nil, addr n, addr ana) == 0
    check glyphes_exec_returning(dbh, "CREATE (n:person) RETURN id(n) AS id".cstring,
                                 nil, addr n, addr bo) == 0
    var edgeId: int64 = 0
    check glyphes_link_props(
      dbh, ana, "SIMILAR_TO".cstring, bo,
      "{\"weight\": 0.867, \"evidence\": \"iptv\"}".cstring, addr edgeId
    ) == 0
    check edgeId > 0

    var buf: array[512, char]
    var need: csize_t = 0
    check glyphes_edge_props(dbh, edgeId, addr buf[0], csize_t(buf.len), addr need) == 0
    let json = $cast[cstring](addr buf[0])
    check "0.867" in json
    check "iptv" in json
    discard glyphes_close(dbh)

  test "link_props joins the caller's transaction and refuses a bad map":
    ## Two things the happy path cannot see. The door joins an open
    ## transaction, so a rollback undoes the edge — it never commits
    ## behind the caller's back. And a property map that is not a JSON
    ## object is refused before a transaction opens, so there is no edge
    ## to roll back either.
    let path = abiPath("link_props_tx")
    let dbh = openAbi(path)
    var n: int64 = 0
    var ana: int64 = 0
    var bo: int64 = 0
    check glyphes_exec_returning(dbh,
      "CREATE (n:person) RETURN id(n) AS id".cstring, nil, addr n, addr ana) == 0
    check glyphes_exec_returning(dbh,
      "CREATE (n:person) RETURN id(n) AS id".cstring, nil, addr n, addr bo) == 0

    var tx: GlyHandle
    check glyphes_tx_begin(dbh, addr tx) == 0
    var edgeId: int64 = 0
    check glyphes_link_props(dbh, ana, "KNOWS".cstring, bo,
                             "{\"weight\": 1.5}".cstring, addr edgeId) == 0
    check edgeId > 0
    check glyphes_tx_rollback(dbh, tx) == 0
    var got: int64 = 0
    check glyphes_exec_returning(dbh,
      "MATCH ()-[r:KNOWS]->() RETURN count(r) AS n".cstring, nil,
      addr n, addr got) == 0
    check got == 0

    var refused: int64 = 0
    check glyphes_link_props(dbh, ana, "KNOWS".cstring, bo,
                             "[]".cstring, addr refused) != 0
    check "JSON object" in globalErrorMsg()
    check refused == 0
    check glyphes_exec_returning(dbh,
      "MATCH ()-[r:KNOWS]->() RETURN count(r) AS n".cstring, nil,
      addr n, addr got) == 0
    check got == 0
    discard glyphes_close(dbh)

  test "the link doors see the transaction's own writes":
    ## The doors join an open transaction, and a node created in that
    ## transaction is not in the store's arrays until commit. Checking
    ## the store refused both ends by name even though `createEdge`
    ## validates through `nodeExistsTx` and would have written the edge:
    ## a loader that creates and links in one transaction could not.
    let path = abiPath("link_same_tx")
    let dbh = openAbi(path)
    var tx: GlyHandle
    check glyphes_tx_begin(dbh, addr tx) == 0
    var n: int64 = 0
    var ana: int64 = 0
    var bo: int64 = 0
    check glyphes_exec_returning(dbh,
      "CREATE (n:person) RETURN id(n) AS id".cstring, nil, addr n, addr ana) == 0
    check glyphes_exec_returning(dbh,
      "CREATE (n:person) RETURN id(n) AS id".cstring, nil, addr n, addr bo) == 0
    check ana > 0 and bo > 0

    var plain: int64 = 0
    check glyphes_link(dbh, ana, "KNOWS".cstring, bo, addr plain) == 0
    check plain > 0
    var weighted: int64 = 0
    check glyphes_link_props(dbh, ana, "SIMILAR_TO".cstring, bo,
                             "{\"weight\": 0.5}".cstring, addr weighted) == 0
    check weighted > 0
    check glyphes_tx_commit(dbh, tx) == 0

    var edges: int64 = 0
    check glyphes_exec_returning(dbh,
      "MATCH ()-[r]->() RETURN count(r) AS n".cstring, nil,
      addr n, addr edges) == 0
    check edges == 2
    var buf: array[256, char]
    var need: csize_t = 0
    check glyphes_edge_props(dbh, weighted, addr buf[0], csize_t(buf.len),
                             addr need) == 0
    check "0.5" in $cast[cstring](addr buf[0])
    discard glyphes_close(dbh)

  test "the link door refuses a missing node by name":
    let path = abiPath("missing")
    let dbh = openAbi(path)
    var n: int64 = 0
    var ana: int64 = 0
    check glyphes_exec_returning(dbh, "CREATE (n:person) RETURN id(n) AS id".cstring, nil, addr n,
                                 addr ana) == 0
    var edgeId: int64 = 0
    check glyphes_link(dbh, ana, "KNOWS".cstring, 9999, addr edgeId) != 0
    check "9999" in globalErrorMsg()
    discard glyphes_close(dbh)

  test "the link door joins an open transaction, so a rollback undoes it":
    ## An autocommit inside an open transaction would take the caller's
    ## choice of rollback away — the same reason `glyphes_exec` joins.
    let path = abiPath("join")
    let dbh = openAbi(path)
    var n: int64 = 0
    var ana: int64 = 0
    var bo: int64 = 0
    check glyphes_exec_returning(dbh, "CREATE (n:person) RETURN id(n) AS id".cstring, nil, addr n,
                                 addr ana) == 0
    check glyphes_exec_returning(dbh, "CREATE (n:person) RETURN id(n) AS id".cstring, nil, addr n,
                                 addr bo) == 0
    var txh: GlyHandle
    check glyphes_tx_begin(dbh, addr txh) == 0
    var edgeId: int64 = 0
    check glyphes_link(dbh, ana, "KNOWS".cstring, bo, addr edgeId) == 0
    check glyphes_tx_rollback(dbh, txh) == 0

    var stmt: GlyHandle
    check glyphes_gq_prepare(dbh, "go KNOWS from $p".cstring,
                             ("{\"p\": " & $ana & "}").cstring, addr stmt) == 0
    var cells: array[4, GlyCell]
    var rows: csize_t = 0
    discard glyphes_gq_step(stmt, addr cells[0], csize_t(cells.len), addr rows)
    check rows == 0
    discard glyphes_stmt_close(stmt)
    discard glyphes_close(dbh)

  test "a parameter that collides with the compiler's own is refused":
    ## The compiler's `$p1` and the caller's `p1` are different values,
    ## and a statement that quietly runs with the wrong one is the
    ## failure this layer exists to prevent.
    var clen: csize_t = 0
    var plen: csize_t = 0
    let status = glyphes_gq_compile("add person {name \"Ada\"}".cstring,
                                    "{\"p1\": 1}".cstring, nil, 0, addr clen,
                                    nil, 0, addr plen)
    check status != 0
    check "p1" in globalErrorMsg()
